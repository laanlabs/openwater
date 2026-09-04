import OpenWaterCore
import SwiftUI

/// Say where you were actually trying to go.
///
/// VMG is progress along an axis, and by default the axis is the wind's:
/// upwind means toward where it blows from. On a river that is the wrong
/// question. The wind at Rufus comes from 258° and the Columbia runs at
/// about 240°, so a rider working up the gorge is not trying to reach 258° —
/// that bearing is a bank. Measured to the wind, their beat looks like it
/// wandered; measured to where they were going, it reads as the beat it was.
///
/// The same dial the wind is set on, with the same track under it, so a rider
/// points the arrow up the river the way they pointed the wind arrow across
/// it. The wind stays on the dial, faint, because the number that matters
/// here is the angle *between* them: a course a few degrees off the wind is a
/// beat measured honestly; a course sixty degrees off is a reach, and the
/// sheet says so rather than letting a big number pass as upwind.
struct CourseSetterView: View {

    let trackPoints: [TrackPoint]
    let wind: Wind
    /// The course already set, or nil for "the wind".
    let initial: Double?
    /// Hands back the chosen bearing, or nil to go back to measuring dead
    /// upwind.
    let onApply: (Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var direction: Double = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(trackPoints.isEmpty
                         ? "Drag the arrow to point the way you were trying to go."
                         : "Drag the arrow to point the way you were trying to go — up the river, out to the mark. VMG is measured toward it instead of straight into the wind.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)

                    dial
                        .frame(width: 300, height: 300)

                    HStack(spacing: 6) {
                        Text(Format.cardinal(direction))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("\(Int(direction.rounded()))°")
                            .font(.system(size: 30, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(direction))

                    Text("heading toward")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(offWindLine)
                        .font(.caption)
                        .foregroundStyle(offWind > 45 ? .orange : .secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: Int(offWind))

                    nudges

                    Button {
                        withAnimation(.snappy) { direction = wind.directionFrom }
                    } label: {
                        Label("Straight into the wind · \(Int(wind.directionFrom.rounded()))°", systemImage: "wind")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(abs(offWind) < 0.5)
                    .padding(.top, 4)

                    Text("Straight into the wind is the number you compare across sessions. A course replaces it only for this one, and only for made-good: which legs count as upwind, and which tack they were on, are still measured to the wind.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .navigationTitle("Made Good Toward")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Set the course")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Back on the wind's own bearing means "no course":
                        // the same number stored two ways would show a
                        // course badge that changes nothing.
                        onApply(abs(offWind) < 0.5 ? nil : Geo.normalizeDegrees(direction.rounded()))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                direction = initial ?? wind.directionFrom
            }
        }
        .presentationDetents([.large])
    }

    /// Signed degrees the course sits off the wind. Positive is clockwise.
    private var offWind: Double {
        Geo.angleDelta(from: wind.directionFrom, to: direction)
    }

    private var offWindLine: String {
        let off = Int(abs(offWind).rounded())
        if off == 0 { return "Straight into the wind — the usual VMG." }
        let side = offWind > 0 ? "right" : "left"
        if off > 90 {
            return "\(off)° off the wind, to the \(side) — that is downwind of a beam reach. Progress this way is not upwind work."
        }
        if off > 45 {
            return "\(off)° off the wind, to the \(side). A course this far off is a reach — the number will be big, and it will not be upwind."
        }
        return "\(off)° off the wind, to the \(side)."
    }

    /// Fine adjustment, because a river's bearing is read off a map to the
    /// degree and a thumb on a 300-point dial is good to about three.
    private var nudges: some View {
        HStack(spacing: 10) {
            nudge(-5, label: "−5°")
            nudge(-1, label: "−1°")
            nudge(1, label: "+1°")
            nudge(5, label: "+5°")
        }
    }

    private func nudge(_ delta: Double, label: String) -> some View {
        Button(label) {
            withAnimation(.snappy) {
                direction = Geo.normalizeDegrees(direction.rounded() + delta)
            }
        }
        .buttonStyle(.bordered)
        .font(.subheadline.weight(.semibold).monospacedDigit())
    }

    // MARK: - Dial

    private var dial: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)

            ZStack {
                Circle()
                    .fill(Color(.secondarySystemGroupedBackground))
                Circle()
                    .strokeBorder(.quaternary, lineWidth: 1)

                ForEach(0..<24, id: \.self) { tick in
                    Capsule()
                        .fill(tick % 6 == 0 ? Color.secondary : Color(.systemGray4))
                        .frame(width: 2, height: tick % 6 == 0 ? 12 : 6)
                        .offset(y: -size / 2 + 12)
                        .rotationEffect(.degrees(Double(tick) * 15))
                }
                ForEach(Array([(0, "N"), (90, "E"), (180, "S"), (270, "W")]), id: \.0) { degrees, label in
                    Text(label)
                        .font(.caption.weight(degrees == 0 ? .bold : .medium))
                        .foregroundStyle(degrees == 0 ? .primary : .secondary)
                        .offset(y: -size / 2 + 30)
                        .rotationEffect(.degrees(Double(degrees)))
                }

                if !trackPoints.isEmpty {
                    trackShape
                        .stroke(.tint.opacity(0.65), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: size * 0.52, height: size * 0.52)
                }

                // The wind, for reference: where it comes from, faint, so
                // the gap between it and the course is the thing you see.
                windMarker(size: size)
                    .rotationEffect(.degrees(wind.directionFrom))

                // The course: a line through the middle of the track to the
                // rim, with the head at the rim pointing *outward* — this is
                // where you were going.
                courseArrow(size: size)
                    .rotationEffect(.degrees(direction))
            }
            .contentShape(Circle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - centre.x
                        let dy = value.location.y - centre.y
                        guard dx * dx + dy * dy > 100 else { return }
                        direction = Geo.normalizeDegrees(Double(atan2(dx, -dy)) * 180 / Double.pi)
                    }
            )
        }
    }

    private func courseArrow(size: CGFloat) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(.tint)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(radius: 2)
            Rectangle()
                .fill(.tint.opacity(0.5))
                .frame(width: 2.5, height: size / 2 - 34 - 8)
            Spacer()
        }
        .frame(height: size - 8)
        .padding(.top, 4)
    }

    private func windMarker(size: CGFloat) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.indigo.opacity(0.7))
                .padding(.top, 44)
            Text("wind")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.indigo.opacity(0.7))
            Spacer()
        }
        .frame(height: size - 8)
        .padding(.top, 4)
    }

    private var trackShape: some Shape {
        var thinned: [(Double, Double)] = []
        let points = trackPoints
        let stride = max(1, points.count / 300)
        var i = 0
        while i < points.count {
            thinned.append((points[i].latitude, points[i].longitude))
            i += stride
        }
        return TrackPathShape(coordinates: thinned)
    }
}
